// Zera o banco do server/.env e cria os dados de teste (usuários de cada
// perfil e alguns veículos). Útil antes de uma rodada de testes do grupo.
//
// Uso, dentro de server/:
//   dart run tool/reiniciar_banco.dart --confirmar
//
// CUIDADO: apaga TUDO (solicitações, notificações, aparelhos, veículos,
// usuários e os logins no Supabase Auth). Não tem como desfazer.
// O esquema (tabelas, migrations) não é alterado.
//
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:frota_server/src/config.dart';
import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';

/// Senha de todos os usuários de teste (regra 6.2: 6+ caracteres,
/// 1 número e 1 caractere especial).
const senha = 'Teste@123';

const usuarios = [
  (email: 'admin@teste.com', nome: 'Admin Teste', perfil: 'administrador',
      cargo: 'Gestor de frota', setor: 'Administrativo', cnh: false),
  (email: 'aprovador1@teste.com', nome: 'Aprovador Um', perfil: 'aprovador',
      cargo: 'Coordenador', setor: 'Operações', cnh: false),
  (email: 'aprovador2@teste.com', nome: 'Aprovador Dois', perfil: 'aprovador',
      cargo: 'Gerente', setor: 'Comercial', cnh: false),
  (email: 'padrao1@teste.com', nome: 'Padrão Um', perfil: 'padrao',
      cargo: 'Técnico de campo', setor: 'Operações', cnh: true),
  (email: 'padrao2@teste.com', nome: 'Padrão Dois', perfil: 'padrao',
      cargo: 'Vendedor', setor: 'Comercial', cnh: true),
  (email: 'padrao3@teste.com', nome: 'Padrão Três', perfil: 'padrao',
      cargo: 'Analista', setor: 'Financeiro', cnh: true),
];

const veiculos = [
  (placa: 'TST-1A11', chassi: '9BWZZZ377VT000001', modelo: 'Fiat Argo',
      cor: 'Branco', ano: 2023, lugares: 5, km: 18500, tipo: 'passeio'),
  (placa: 'TST-2B22', chassi: '9BWZZZ377VT000002', modelo: 'Chevrolet Onix',
      cor: 'Prata', ano: 2022, lugares: 5, km: 32700, tipo: 'passeio'),
  (placa: 'TST-3C33', chassi: '9BWZZZ377VT000003', modelo: 'Fiat Strada',
      cor: 'Vermelho', ano: 2021, lugares: 2, km: 54200, tipo: 'utilitario'),
  (placa: 'TST-4D44', chassi: '9BWZZZ377VT000004', modelo: 'Renault Master',
      cor: 'Branco', ano: 2020, lugares: 15, km: 88900, tipo: 'van'),
];

Future<void> main(List<String> args) async {
  if (!args.contains('--confirmar')) {
    print('Isto APAGA todos os dados do banco do server/.env.');
    print('Para continuar: dart run tool/reiniciar_banco.dart --confirmar');
    exit(64);
  }

  final config = Config.fromEnvironment();
  final authUrl = config.supabaseUrl.resolve('/auth/v1/');
  final headers = {
    'apikey': config.supabaseSecretKey,
    'Authorization': 'Bearer ${config.supabaseSecretKey}',
    'Content-Type': 'application/json',
  };
  final db = Pool<void>.withUrl(config.databaseUrl);

  try {
    // 1. Dados do app (os ids voltam a começar do 1).
    final logins = await db.execute('SELECT auth_id::text FROM usuarios');
    await db.execute(
      'TRUNCATE notificacoes, dispositivos, solicitacoes, veiculos, usuarios '
      'RESTART IDENTITY CASCADE',
    );
    print('✓ Tabelas zeradas');

    // 2. Logins no Supabase Auth (os do app e qualquer um que tenha sobrado).
    final sobras = await db.execute('SELECT id::text FROM auth.users');
    final ids = {
      for (final r in logins) r.first! as String,
      for (final r in sobras) r.first! as String,
    };
    for (final id in ids) {
      final r = await http.delete(
        authUrl.resolve('admin/users/$id'),
        headers: headers,
      );
      if (r.statusCode >= 300 && r.statusCode != 404) {
        throw StateError('Falha ao apagar login $id: ${r.body}');
      }
    }
    print('✓ ${ids.length} logins apagados');

    // 3. Usuários de teste (login + cadastro).
    final cnhValidade = DateTime(DateTime.now().year + 4, 12, 31);
    var n = 0;
    for (final u in usuarios) {
      final r = await http.post(
        authUrl.resolve('admin/users'),
        headers: headers,
        body: jsonEncode({
          'email': u.email,
          'password': senha,
          'email_confirm': true,
        }),
      );
      if (r.statusCode >= 300) {
        throw StateError('Falha ao criar login ${u.email}: ${r.body}');
      }
      final authId = (jsonDecode(r.body) as Map<String, dynamic>)['id'];
      n++;
      await db.execute(
        Sql.named('''
          INSERT INTO usuarios (auth_id, nome, email, telefone, cargo, setor,
            cnh_numero, cnh_categoria, cnh_validade, perfil)
          VALUES (@authId::uuid, @nome, @email, @telefone, @cargo, @setor,
            @cnhNumero, @cnhCategoria, @cnhValidade::date,
            @perfil::perfil_usuario)'''),
        parameters: {
          'authId': authId,
          'nome': u.nome,
          'email': u.email,
          'telefone': '(22) 99999-000$n',
          'cargo': u.cargo,
          'setor': u.setor,
          'cnhNumero': u.cnh ? '0000000000$n' : null,
          'cnhCategoria': u.cnh ? 'B' : null,
          'cnhValidade': u.cnh
              ? cnhValidade.toIso8601String().substring(0, 10)
              : null,
          'perfil': u.perfil,
        },
      );
    }
    print('✓ ${usuarios.length} usuários criados (senha: $senha)');

    // 4. Veículos com documentos em dia.
    final ano = DateTime.now().year + 1;
    for (final v in veiculos) {
      await db.execute(
        Sql.named('''
          INSERT INTO veiculos (placa, chassi, modelo, cor, ano, lugares,
            quilometragem, tipo, vencimento_licenciamento, vencimento_seguro,
            proxima_revisao_km)
          VALUES (@placa, @chassi, @modelo, @cor, @ano, @lugares, @km,
            @tipo::tipo_veiculo, @lic::date, @seg::date, @revisao)'''),
        parameters: {
          'placa': v.placa,
          'chassi': v.chassi,
          'modelo': v.modelo,
          'cor': v.cor,
          'ano': v.ano,
          'lugares': v.lugares,
          'km': v.km,
          'tipo': v.tipo,
          'lic': '$ano-03-31',
          'seg': '$ano-08-31',
          'revisao': (v.km ~/ 10000 + 1) * 10000,
        },
      );
    }
    print('✓ ${veiculos.length} veículos criados');

    for (final u in usuarios) {
      print('   ${u.perfil.padRight(13)} ${u.email}');
    }
  } finally {
    await db.close();
  }
}
